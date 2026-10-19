import Foundation

struct DuplicateAnalysisSummary {
    let groups: Int
    let highConfidenceGroups: Int
    let mediumConfidenceGroups: Int
    let lowConfidenceGroups: Int
    let extraCopies: Int
    let reviewItems: Int
    /// Star pairs that are alike but NOT copies — whole-file digests known
    /// and different, lengths agreeing (DuplicateLikeness.Relationship
    /// .sameFootage). Never grouped as copies; Find Similar Footage records
    /// them as "same footage, different file" (2026-10-19).
    var sameFootageLinks: Int = 0
    /// Star pairs whose digests differ AND whose lengths disagree — the
    /// sampled-hash collision class. Neither copies nor the same footage.
    var differentLength: Int = 0
}

// DuplicateDetector — groups of COPIES.
//
// Since 2026-10-19 the likeness rule itself (scoring table, bucket keys,
// stars, hub election) lives in DuplicateLikeness.swift, shared with Find
// Similar Footage; this file stamps the duplicate-group fields. A group is
// a set of copies (Rick 2026-10-19): each star is partitioned by whole-file
// SHA-256 (DuplicateGroupDigestSplit.partition) before it is stamped. The
// star pairs whose digests differ are not dropped knowledge: they are
// counted here (`sameFootageLinks`) and recorded by Find Similar Footage as
// footage links with the same reasons (FootageGrouping `copyCheckLikeness`).
//
// (For Rick: the detector now works on value snapshots by INDEX —
// `facts[i]` mirrors `candidates[i]`, like parallel arrays in C — so a pair
// lookup is a hash probe, not the old linear `records.first(where:)` scan
// per pair.)
enum DuplicateDetector {

    /// - Parameter keeperPolicy: volume precedence + human-metadata rules
    ///   for the keeper election (2026-08-18). Grouping is unaffected by
    ///   it. Defaults to `.unconfigured` (no volume facts, no list) so the
    ///   pre-existing call sites and tests keep their behavior modulo the
    ///   now-deterministic tie-break.
    static func analyze(records inputRecords: [VideoRecord],
                        keeperPolicy: DuplicateKeeperPolicy = .unconfigured) -> DuplicateAnalysisSummary {
        // Global-inert: purged records do not participate in duplicate
        // detection (a removed-from-catalog file shouldn't pull a live record
        // into a duplicate group). Filter at the entry point.
        let records = pfActiveRecords(inputRecords)
        clear(records: records)

        let allFacts = records.map { DuplicateLikeness.Facts(record: $0) }
        var candidates: [VideoRecord] = []
        var facts: [DuplicateLikeness.Facts] = []
        for (r, f) in zip(records, allFacts) where DuplicateLikeness.isCandidate(f) {
            candidates.append(r)
            facts.append(f)
        }
        guard candidates.count > 1 else { return emptySummary }

        let scored = DuplicateLikeness.pairs(facts)
        guard !scored.isEmpty else { return emptySummary }

        // Star-topology grouping (codex review C, 2026-08-18): the HUB is
        // the best-CONNECTED member; only records that score against the
        // hub directly join, so A↔B↔C chains cannot inflate a group. The
        // keeper is then elected AMONG the star members by the policy.
        var tally = Tally()
        for star in DuplicateLikeness.stars(facts, pairs: scored) {
            let starRecords = star.members.map { candidates[$0] }
            let keeperRecord = electKeeper(from: starRecords, policy: keeperPolicy) ?? candidates[star.hub]
            let keeperIndex = star.members.first { candidates[$0] === keeperRecord }

            // A group is a set of COPIES (Rick 2026-10-19): members whose
            // stored whole-file SHA-256s are known and differ are never
            // stamped into one group, whatever the sampled hash said. The
            // keeper's copies stay its group; other copies form their own;
            // a file with no copy here stays ungrouped.
            let copies = DuplicateGroupDigestSplit.partition(
                star.members, keeper: keeperIndex.flatMap { k in star.members.firstIndex(of: k) },
                digest: { facts[$0].digest })
            for members in copies {
                let groupKeeper = keeperIndex.flatMap { k in members.contains(k) ? k : nil }
                    ?? electKeeper(from: members.map { candidates[$0] }, policy: keeperPolicy)
                        .flatMap { elected in members.first { candidates[$0] === elected } }
                    ?? members[0]
                let result = classifyGroup(members, keeper: groupKeeper, candidates: candidates, scored: scored)
                tally.add(result)
            }
            // The likeness that is not "copy" — counted, never stamped.
            for m in star.members.dropFirst() {
                guard let s = scored[DuplicateLikeness.PairKey(star.hub, m)] else { continue }
                switch DuplicateLikeness.relationship(facts[m], facts[star.hub], reasons: s.reasons) {
                case .sameFootage: tally.sameFootage += 1
                case .differentLength: tally.differentLength += 1
                case .copies, .unknown: break
                }
            }
        }
        return tally.summary
    }

    private struct Tally {
        var groups = 0, high = 0, medium = 0, low = 0, extras = 0, reviews = 0
        var sameFootage = 0, differentLength = 0

        mutating func add(_ r: (confidence: DuplicateConfidence, extraCopies: Int, reviewItems: Int)) {
            groups += 1
            switch r.confidence {
            case .high: high += 1
            case .medium: medium += 1
            case .low: low += 1
            }
            extras += r.extraCopies
            reviews += r.reviewItems
        }

        var summary: DuplicateAnalysisSummary {
            DuplicateAnalysisSummary(groups: groups, highConfidenceGroups: high, mediumConfidenceGroups: medium,
                                     lowConfidenceGroups: low, extraCopies: extras, reviewItems: reviews,
                                     sameFootageLinks: sameFootage, differentLength: differentLength)
        }
    }

    /// Stamp one group of copies. `members` and `keeper` are indices into
    /// `candidates` (and the scored pairs).
    private static func classifyGroup(
        _ members: [Int], keeper: Int, candidates: [VideoRecord], scored: [DuplicateLikeness.PairKey: DuplicateLikeness.Score]
    ) -> (confidence: DuplicateConfidence, extraCopies: Int, reviewItems: Int) {
        let groupID = UUID()
        let groupConfidence = members.compactMap { bestPair(for: $0, in: members, scored: scored)?.score.confidence }
            .max() ?? .low
        var extras = 0
        var reviews = 0
        for i in members {
            let item = candidates[i]
            let best = bestPair(for: i, in: members, scored: scored)
            item.duplicateGroupID = groupID
            item.duplicateGroupCount = members.count
            item.duplicateConfidence = members.compactMap { j -> DuplicateConfidence? in
                j == i ? nil : scored[DuplicateLikeness.PairKey(i, j)]?.confidence
            }.max() ?? groupConfidence
            let reasons = best?.score.reasons ?? []
            item.duplicateReasons = reasons.isEmpty
                ? members.flatMap { bestPair(for: $0, in: members, scored: scored)?.score.reasons ?? [] }
                    .uniqued().joined(separator: "+")
                : reasons.joined(separator: "+")
            item.duplicateBestMatchFilename = i == keeper
                ? best.map { candidates[$0.other].filename } ?? ""
                : candidates[keeper].filename
            if i == keeper {
                item.duplicateDisposition = .keep
            } else if item.duplicateConfidence == .high {
                item.duplicateDisposition = .extraCopy
                extras += 1
            } else {
                item.duplicateDisposition = .review
                reviews += 1
            }
        }
        return (groupConfidence, extras, reviews)
    }

    /// The highest-scoring pair `i` has with another member (the first one
    /// in member order on a tie — the old `max(by:)` behavior).
    private static func bestPair(for i: Int, in members: [Int],
                                 scored: [DuplicateLikeness.PairKey: DuplicateLikeness.Score])
        -> (other: Int, score: DuplicateLikeness.Score)? {
        var best: (other: Int, score: DuplicateLikeness.Score)?
        for j in members where j != i {
            guard let s = scored[DuplicateLikeness.PairKey(i, j)] else { continue }
            if let b = best, s.points <= b.score.points { continue }
            best = (j, s)
        }
        return best
    }

    private static let emptySummary = DuplicateAnalysisSummary(
        groups: 0, highConfidenceGroups: 0, mediumConfidenceGroups: 0,
        lowConfidenceGroups: 0, extraCopies: 0, reviewItems: 0
    )

    static func clear(records: [VideoRecord]) {
        for record in records {
            record.duplicateGroupID = nil
            record.duplicateConfidence = nil
            record.duplicateDisposition = .none
            record.duplicateReasons = ""
            record.duplicateBestMatchFilename = ""
            record.duplicateGroupCount = 0
        }
    }

    /// The three bucket keys a record can pair under — hash, timecode,
    /// and normalized-stem, each namespaced so families never collide.
    /// Shared by grouping (DuplicateLikeness.pairs) and `affectedSubset`
    /// (the analysis-ledger delta expansion) so they can never drift.
    static func bucketKeys(_ record: VideoRecord) -> [String] {
        DuplicateLikeness.bucketKeys(DuplicateLikeness.Facts(record: record))
    }

    // MARK: - Analysis-ledger support (2026-07-05)

    /// The re-analysis subset for a pending delta: the delta records plus
    /// the TRANSITIVE closure of bucket-key adjacency (grouping walks
    /// connected components, so one hop is not enough — QA P1-3), plus the
    /// FULL existing group of every included record (a partial group
    /// re-derivation would fragment identities). Everything outside this
    /// closure provably cannot change: a record with no bucket-key chain
    /// to any delta record can never share a component with it.
    static func affectedSubset(delta: [VideoRecord],
                               allActive: [VideoRecord]) -> [VideoRecord] {
        guard !delta.isEmpty else { return [] }
        // Index once: bucket key → member indices, and per-record keys.
        var byKey: [String: [Int]] = [:]
        var keysOf: [[String]] = []
        keysOf.reserveCapacity(allActive.count)
        for (i, r) in allActive.enumerated() {
            let keys = bucketKeys(r)
            keysOf.append(keys)
            for k in keys { byKey[k, default: []].append(i) }
        }
        var indexOfID: [UUID: Int] = [:]
        for (i, r) in allActive.enumerated() { indexOfID[r.id] = i }

        // BFS over bucket-key adjacency to a fixpoint.
        var includedIdx = Set<Int>()
        var frontier: [Int] = []
        for r in delta {
            guard let i = indexOfID[r.id], includedIdx.insert(i).inserted else { continue }
            frontier.append(i)
        }
        var visitedKeys = Set<String>()
        var affectedGroupIDs = Set<UUID>()
        while let i = frontier.popLast() {
            if let g = allActive[i].duplicateGroupID { affectedGroupIDs.insert(g) }
            for key in keysOf[i] where visitedKeys.insert(key).inserted {
                for j in byKey[key] ?? [] where includedIdx.insert(j).inserted {
                    frontier.append(j)
                }
            }
        }
        // Pull the FULL groups of everything reached (group members with
        // no shared bucket key — e.g. star members admitted via a key the
        // delta chain didn't touch — must still re-derive together).
        if !affectedGroupIDs.isEmpty {
            for (i, r) in allActive.enumerated() where !includedIdx.contains(i) {
                if let g = r.duplicateGroupID, affectedGroupIDs.contains(g) {
                    includedIdx.insert(i)
                }
            }
        }
        return includedIdx.sorted().map { allActive[$0] }
    }

    /// Run `analyze` OFF the main actor over exclusively-owned clones
    /// (`snapshotClone` — the same contract CatalogStore's off-main save
    /// uses). The caller clones on main, hands the clones here, and copies
    /// the six result fields back on main; the live record graph is never
    /// touched off-actor.
    ///
    /// `sending` in/out (2026-07-07): the clones cross the main-actor →
    /// @concurrent boundary and back. Declaring the transfer lets region
    /// analysis PROVE what the snapshotClone contract already guarantees
    /// (exclusively-owned disconnected copies) instead of warning about
    /// it. The caller must use the RETURNED array for the copy-back —
    /// its argument is consumed by the send. Same objects, so the
    /// position-zip against `scope` is unchanged.
    // #if guard: the nightly CI's Xcode 16.4 (Swift 6.1) knows
    // `@concurrent` only as a deprecated alias of `@Sendable` and warns;
    // pre-6.2 a nonisolated async static already runs off-actor, so
    // omitting the attribute there is behavior-identical.
    #if compiler(>=6.2)
    @concurrent
    #endif
    static func analyzeDetached(
        _ clones: sending [VideoRecord],
        keeperPolicy: DuplicateKeeperPolicy = .unconfigured
    ) async -> sending (analyzed: [VideoRecord], summary: DuplicateAnalysisSummary) {
        let summary = analyze(records: clones, keeperPolicy: keeperPolicy)
        return (clones, summary)
    }

    // MARK: - Keeper re-election under a changed policy (2026-08-18, codex review B)

    /// Re-elect the keeper of EVERY existing group among `clones` under
    /// `policy` — no pair building, no re-grouping: membership,
    /// confidence and reasons are kept; only `duplicateDisposition` and
    /// `duplicateBestMatchFilename` move. Runs off-main over snapshot
    /// clones exactly like `analyzeDetached`. Returns the number of groups
    /// whose keeper changed.
    static func reelectKeepersDetached(
        _ clones: sending [VideoRecord],
        keeperPolicy: DuplicateKeeperPolicy
    ) async -> sending (analyzed: [VideoRecord], changedGroups: Int) {
        var byGroup: [UUID: [VideoRecord]] = [:]
        for rec in clones {
            guard let g = rec.duplicateGroupID else { continue }
            byGroup[g, default: []].append(rec)
        }
        var changed = 0
        for (_, members) in byGroup where members.count > 1 {
            guard let keeper = electKeeper(from: members, policy: keeperPolicy) else { continue }
            let previous = members.first { $0.duplicateDisposition == .keep }
            guard previous !== keeper else { continue }
            changed += 1
            // Codex follow-up NOTE 2: the new keeper's best match is the
            // STRONGEST-scoring other member — the same rule
            // classifyGroup applies — not simply the old keeper. Groups
            // are small, so re-scoring the members' pairs here is cheap.
            let facts = members.map { DuplicateLikeness.Facts(record: $0) }
            var scored: [DuplicateLikeness.PairKey: DuplicateLikeness.Score] = [:]
            for i in 0..<(members.count - 1) {
                for j in (i + 1)..<members.count {
                    if let s = DuplicateLikeness.score(facts[i], facts[j]) { scored[DuplicateLikeness.PairKey(i, j)] = s }
                }
            }
            let keeperIndex = members.firstIndex { $0 === keeper } ?? 0
            let strongest = bestPair(for: keeperIndex, in: Array(members.indices), scored: scored)
                .map { members[$0.other].filename } ?? ""
            for m in members {
                if m === keeper {
                    m.duplicateDisposition = .keep
                    // Same rule as classifyGroup: an elected keeper with no
                    // currently-scoring pair gets an EMPTY best match — never
                    // the old keeper's filename, which may no longer be a
                    // valid match and would mislead the UI (codex #474,
                    // 2026-08-18).
                    m.duplicateBestMatchFilename = strongest
                } else {
                    // The old keeper (and anyone marked keep) becomes an
                    // extra or review item by ITS OWN confidence, exactly
                    // as classifyGroup would have said.
                    if m.duplicateDisposition == .keep {
                        m.duplicateDisposition = m.duplicateConfidence == .high ? .extraCopy : .review
                    }
                    m.duplicateBestMatchFilename = keeper.filename
                }
            }
        }
        return (clones, changed)
    }

    // MARK: - Keeper election (2026-08-18)

    /// Elect the group's keeper: lexicographic max of (volume precedence,
    /// human-metadata score, technical `keeperScore`, path). See
    /// DuplicateKeeperPolicy for the WHY (8/14 offline-strand finding,
    /// 8/17 volume-provenance finding). Before this the election was
    /// `keeperScore` alone, which ties for byte-identical copies and
    /// left the winner to input order.
    ///
    /// Keys are computed ONCE per member (O(component)), not inside the
    /// comparator, so a 100k-record catalog adds no quadratic work.
    static func electKeeper(from component: [VideoRecord],
                            policy: DuplicateKeeperPolicy) -> VideoRecord? {
        var bestRecord: VideoRecord?
        var bestKey: DuplicateKeeperPolicy.ElectionKey?
        for record in component {
            let key = policy.electionKey(for: record, technicalScore: keeperScore(record))
            if let current = bestKey, !(key > current) { continue }
            bestRecord = record
            bestKey = key
        }
        return bestRecord
    }

    /// TECHNICAL keeper merit — playability, streams, codecs, size,
    /// resolution, date. Since 2026-08-18 this is the THIRD key of the
    /// election (after volume precedence and human metadata), no longer
    /// the whole vote. Internal-visible so DuplicateKeeperPolicy tests
    /// can build expected keys. The rule is DuplicateLikeness's (shared
    /// with the hub election).
    static func keeperScore(_ record: VideoRecord) -> Int {
        DuplicateLikeness.technicalScore(isPlayable: record.isPlayable, streamType: record.streamType,
                                         audioCodec: record.audioCodec, videoCodec: record.videoCodec,
                                         sizeBytes: record.sizeBytes, resolution: record.resolution,
                                         dateCreatedRaw: record.dateCreatedRaw)
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
