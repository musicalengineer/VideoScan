import Foundation

struct DuplicateAnalysisSummary {
    let groups: Int
    let highConfidenceGroups: Int
    let mediumConfidenceGroups: Int
    let lowConfidenceGroups: Int
    let extraCopies: Int
    let reviewItems: Int
}

enum DuplicateDetector {
    private static let durationToleranceExact = 0.25
    private static let durationToleranceLoose = 1.0
    private static let creationTolerance: TimeInterval = 5 * 60

    struct Candidate {
        let left: VideoRecord
        let right: VideoRecord
        let score: Int
        let confidence: DuplicateConfidence
        let reasons: [String]
    }

    static func analyze(records inputRecords: [VideoRecord]) -> DuplicateAnalysisSummary {
        // Global-inert: purged records do not participate in duplicate
        // detection (a removed-from-catalog file shouldn't pull a live record
        // into a duplicate group). Filter at the entry point.
        let records = pfActiveRecords(inputRecords)
        clear(records: records)

        let candidates = records.filter(isDuplicateCandidate)
        guard candidates.count > 1 else {
            return emptySummary
        }

        let pairs = buildCandidatePairs(from: candidates)
        guard !pairs.isEmpty else {
            return emptySummary
        }

        var pairByIDs: [PairKey: Candidate] = [:]
        for pair in pairs {
            pairByIDs[PairKey(pair.left.id, pair.right.id)] = pair
        }

        // Star-topology grouping: elect a keeper first, then only include
        // records that score against the keeper directly.  This prevents
        // transitive contamination where A↔B↔C chains inflate groups with
        // unrelated files.
        let recordsByID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0) })
        var assigned = Set<UUID>()
        var groups = 0
        var highGroups = 0
        var mediumGroups = 0
        var lowGroups = 0
        var extraCopies = 0
        var reviewItems = 0

        // Build adjacency for initial keeper election
        var adjacency: [UUID: Set<UUID>] = [:]
        for pair in pairs {
            adjacency[pair.left.id, default: []].insert(pair.right.id)
            adjacency[pair.right.id, default: []].insert(pair.left.id)
        }

        var visited = Set<UUID>()
        for record in candidates where !visited.contains(record.id) {
            guard adjacency[record.id] != nil else { continue }

            let componentIDs = walkComponent(from: record.id, adjacency: adjacency, visited: &visited)
            guard componentIDs.count > 1 else { continue }
            let component = componentIDs.compactMap { recordsByID[$0] }
            guard let keeper = component.max(by: { keeperScore($0) < keeperScore($1) }) else { continue }

            let starMembers = buildStarMembers(keeper: keeper, component: component, pairByIDs: pairByIDs)
            guard starMembers.count > 1 else { continue }

            let result = classifyGroup(
                starMembers: starMembers, keeper: keeper,
                pairByIDs: pairByIDs, assigned: &assigned
            )

            groups += 1
            switch result.confidence {
            case .high: highGroups += 1
            case .medium: mediumGroups += 1
            case .low: lowGroups += 1
            }
            extraCopies += result.extraCopies
            reviewItems += result.reviewItems
        }

        return DuplicateAnalysisSummary(
            groups: groups,
            highConfidenceGroups: highGroups,
            mediumConfidenceGroups: mediumGroups,
            lowConfidenceGroups: lowGroups,
            extraCopies: extraCopies,
            reviewItems: reviewItems
        )
    }

    private static func walkComponent(from startID: UUID, adjacency: [UUID: Set<UUID>], visited: inout Set<UUID>) -> [UUID] {
        var stack = [startID]
        var componentIDs: [UUID] = []
        while let id = stack.popLast() {
            guard visited.insert(id).inserted else { continue }
            componentIDs.append(id)
            for next in adjacency[id] ?? [] where !visited.contains(next) {
                stack.append(next)
            }
        }
        return componentIDs
    }

    private static func buildStarMembers(keeper: VideoRecord, component: [VideoRecord], pairByIDs: [PairKey: Candidate]) -> [VideoRecord] {
        var members = [keeper]
        for item in component where item !== keeper {
            let key = PairKey(keeper.id, item.id)
            if let pair = pairByIDs[key], pair.score >= scoreThreshold {
                members.append(item)
            }
        }
        return members
    }

    private static func classifyGroup(
        starMembers: [VideoRecord], keeper: VideoRecord,
        pairByIDs: [PairKey: Candidate], assigned: inout Set<UUID>
    ) -> (confidence: DuplicateConfidence, extraCopies: Int, reviewItems: Int) {
        let groupID = UUID()
        let memberIDs = starMembers.map(\.id)
        let groupConfidence = starMembers
            .compactMap { bestConfidence(for: $0, in: memberIDs, pairByIDs: pairByIDs) }
            .max() ?? .low

        var extras = 0
        var reviews = 0

        for item in starMembers {
            assigned.insert(item.id)
            item.duplicateGroupID = groupID
            item.duplicateGroupCount = starMembers.count
            item.duplicateConfidence = bestConfidence(for: item, in: memberIDs, pairByIDs: pairByIDs) ?? groupConfidence
            let reasons = bestReasons(for: item, in: memberIDs, pairByIDs: pairByIDs)
            item.duplicateReasons = reasons.isEmpty
                ? starMembers.flatMap { bestReasons(for: $0, in: memberIDs, pairByIDs: pairByIDs) }
                    .uniqued().joined(separator: "+")
                : reasons.joined(separator: "+")
            item.duplicateBestMatchFilename = keeper === item
                ? strongestMatchFilename(for: item, in: starMembers, pairByIDs: pairByIDs)
                : keeper.filename

            if item === keeper {
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

    private static func buildCandidatePairs(from records: [VideoRecord]) -> [Candidate] {
        var bucketPairs = Set<PairKey>()
        let indices = buildIndices(records: records)

        for bucket in indices where bucket.count > 1 {
            for i in 0..<(bucket.count - 1) {
                for j in (i + 1)..<bucket.count {
                    bucketPairs.insert(PairKey(bucket[i].id, bucket[j].id))
                }
            }
        }

        return bucketPairs.compactMap { key in
            guard
                let left = records.first(where: { $0.id == key.first }),
                let right = records.first(where: { $0.id == key.second })
            else { return nil }
            return score(left: left, right: right)
        }
    }

    /// The three bucket keys a record can pair under — hash, timecode,
    /// and normalized-stem, each namespaced so families never collide.
    /// Shared by `buildIndices` (grouping) and `affectedSubset` (the
    /// analysis-ledger delta expansion) so they can never drift.
    static func bucketKeys(_ record: VideoRecord) -> [String] {
        var keys: [String] = []
        if !record.partialMD5.isEmpty && record.sizeBytes > 0 {
            keys.append("h|\(record.streamTypeRaw)|\(record.sizeBytes)|\(record.partialMD5)")
        }
        if !record.timecode.isEmpty {
            keys.append("t|\(record.streamTypeRaw)|\(record.timecode)|\(durationBucket(record.durationSeconds))")
        }
        let stem = normalizedStem(record.filename)
        if !stem.isEmpty {
            keys.append("s|\(record.streamTypeRaw)|\(stem)|\(durationBucket(record.durationSeconds))")
        }
        return keys
    }

    private static func buildIndices(records: [VideoRecord]) -> [[VideoRecord]] {
        var buckets: [String: [VideoRecord]] = [:]
        for record in records {
            for key in bucketKeys(record) {
                buckets[key, default: []].append(record)
            }
        }
        return Array(buckets.values)
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
        _ clones: sending [VideoRecord]
    ) async -> sending (analyzed: [VideoRecord], summary: DuplicateAnalysisSummary) {
        let summary = analyze(records: clones)
        return (clones, summary)
    }

    // MARK: - Scoring rules
    //
    // Each rule inspects a pair of records and returns either the points
    // earned or nil when the rule does not apply. `score(left:right:)` runs
    // every rule, sums the points, and collects the reason tags for UI.
    // Rules are independent — reordering or adding a rule does not affect
    // any other rule. To tune duplicate detection, edit the rule table or
    // the confidence thresholds below.

    private struct ScoringRule {
        let reason: String
        let evaluate: (VideoRecord, VideoRecord) -> Int?
    }

    private static let scoreThreshold = 7
    private static let mediumConfidenceScore = 9
    private static let highConfidenceScore = 12

    // Static immutable table of pure functions — safe to read concurrently
    // even though ScoringRule isn't Sendable (closure parameter type
    // VideoRecord is a class). The table is built once at type-init and
    // never mutated thereafter.
    nonisolated(unsafe) private static let scoringRules: [ScoringRule] = [
        // Byte-identical content: same hash AND same size. Strongest signal.
        ScoringRule(reason: "hash") { l, r in
            guard !l.partialMD5.isEmpty,
                  l.partialMD5 == r.partialMD5,
                  l.sizeBytes == r.sizeBytes else { return nil }
            return 8
        },
        // Same embedded timecode → almost certainly same source capture.
        ScoringRule(reason: "timecode") { l, r in
            (!l.timecode.isEmpty && l.timecode == r.timecode) ? 4 : nil
        },
        // Filename stems match after stripping "copy", numeric suffixes, etc.
        ScoringRule(reason: "filename") { l, r in
            Self.normalizedStem(l.filename) == Self.normalizedStem(r.filename) ? 3 : nil
        },
        // Duration — tiered: very close is worth more than merely close.
        ScoringRule(reason: "duration") { l, r in
            guard l.durationSeconds > 0, r.durationSeconds > 0 else { return nil }
            let delta = abs(l.durationSeconds - r.durationSeconds)
            if delta <= Self.durationToleranceExact { return 3 }
            if delta <= Self.durationToleranceLoose { return 2 }
            return nil
        },
        ScoringRule(reason: "resolution") { l, r in
            (!l.resolution.isEmpty && l.resolution == r.resolution) ? 2 : nil
        },
        ScoringRule(reason: "vcodec") { l, r in
            (!l.videoCodec.isEmpty && l.videoCodec == r.videoCodec) ? 2 : nil
        },
        ScoringRule(reason: "audio") { l, r in
            Self.audioSignature(l) == Self.audioSignature(r) ? 2 : nil
        },
        ScoringRule(reason: "tape") { l, r in
            (!l.tapeName.isEmpty && l.tapeName == r.tapeName) ? 1 : nil
        },
        // Capture timestamps within a few minutes → likely the same event.
        ScoringRule(reason: "created") { l, r in
            guard let lDate = l.dateCreatedRaw, let rDate = r.dateCreatedRaw,
                  abs(lDate.timeIntervalSince(rDate)) <= Self.creationTolerance else { return nil }
            return 1
        }
    ]

    private static func score(left: VideoRecord, right: VideoRecord) -> Candidate? {
        guard left.streamType == right.streamType else { return nil }

        var total = 0
        var reasons: [String] = []
        for rule in scoringRules {
            if let points = rule.evaluate(left, right) {
                total += points
                reasons.append(rule.reason)
            }
        }

        guard total >= scoreThreshold else { return nil }

        let confidence: DuplicateConfidence
        switch total {
        case highConfidenceScore...:   confidence = .high
        case mediumConfidenceScore...: confidence = .medium
        default:                       confidence = .low
        }

        return Candidate(left: left, right: right, score: total, confidence: confidence, reasons: reasons)
    }

    private static func bestConfidence(for record: VideoRecord, in componentIDs: [UUID], pairByIDs: [PairKey: Candidate]) -> DuplicateConfidence? {
        componentIDs
            .filter { $0 != record.id }
            .compactMap { pairByIDs[PairKey(record.id, $0)]?.confidence }
            .max()
    }

    private static func bestReasons(for record: VideoRecord, in componentIDs: [UUID], pairByIDs: [PairKey: Candidate]) -> [String] {
        let pair = componentIDs
            .filter { $0 != record.id }
            .compactMap { pairByIDs[PairKey(record.id, $0)] }
            .max(by: { $0.score < $1.score })
        return pair?.reasons ?? []
    }

    private static func strongestMatchFilename(for record: VideoRecord, in component: [VideoRecord], pairByIDs: [PairKey: Candidate]) -> String {
        component
            .filter { $0.id != record.id }
            .compactMap { other in
                pairByIDs[PairKey(record.id, other.id)].map { (other.filename, $0.score) }
            }
            .max(by: { $0.1 < $1.1 })?.0 ?? ""
    }

    private static func keeperScore(_ record: VideoRecord) -> Int {
        var score = 0
        if record.isPlayable == "Yes" { score += 40 }

        switch record.streamType {
        case .videoAndAudio: score += 30
        case .videoOnly: score += 20
        case .audioOnly: score += 10
        case .noStreams: score -= 20
        case .ffprobeFailed: score -= 40
        }

        if !record.audioCodec.isEmpty { score += 8 }
        if !record.videoCodec.isEmpty { score += 6 }
        score += min(20, Int(record.sizeBytes / 50_000_000))

        if let pixels = pixelCount(record.resolution) {
            score += min(12, pixels / 500_000)
        }

        if let date = record.dateCreatedRaw {
            score += max(0, 5 - Int(date.timeIntervalSince1970 / 86_400_000))
        }

        return score
    }

    private static func pixelCount(_ resolution: String) -> Int? {
        let parts = resolution.split(separator: "x")
        guard parts.count == 2, let width = Int(parts[0]), let height = Int(parts[1]) else { return nil }
        return width * height
    }

    private static func audioSignature(_ record: VideoRecord) -> String {
        "\(record.audioCodec)|\(record.audioChannels)|\(record.audioSampleRate)"
    }

    private static func normalizedStem(_ filename: String) -> String {
        var stem = (filename as NSString).deletingPathExtension.lowercased()
        let patterns = [
            #"\s*\(\d+\)$"#,
            #"\s+copy(?:\s+\d+)?$"#,
            #"[-_ ]copy(?:[-_ ]\d+)?$"#,
            #"[-_ ]duplicate(?:[-_ ]\d+)?$"#
        ]
        for pattern in patterns {
            stem = stem.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        return stem.replacingOccurrences(of: #"[^a-z0-9]+"#, with: "", options: .regularExpression)
    }

    private static func durationBucket(_ duration: Double) -> Int {
        Int((duration * 2).rounded())
    }

    private static func isDuplicateCandidate(_ record: VideoRecord) -> Bool {
        switch record.streamType {
        case .ffprobeFailed, .noStreams:
            return false
        default:
            break
        }
        if isStockMedia(record) { return false }
        return true
    }

    private static let stockPathPatterns: [String] = [
        "/iMovie",
        "/Final Cut",
        "/FxPlug",
        "/Motion",
        "/Compressor",
        "/Pro Video Formats",
        "/Avid/AVX",
        "/Media Composer",
        "/Transitions/",
        "/Titles/",
        "/Generators/",
        "/Effects/",
        ".app/Contents/"
    ]

    private static func isStockMedia(_ record: VideoRecord) -> Bool {
        let path = record.fullPath
        for pattern in stockPathPatterns {
            if path.contains(pattern) { return true }
        }
        return false
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}

private struct PairKey: Hashable {
    let first: UUID
    let second: UUID

    init(_ a: UUID, _ b: UUID) {
        if a.uuidString < b.uuidString {
            first = a
            second = b
        } else {
            first = b
            second = a
        }
    }
}
