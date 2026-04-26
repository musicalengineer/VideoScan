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

    static func analyze(records: [VideoRecord]) -> DuplicateAnalysisSummary {
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

        // Walk connected components to find keeper candidates
        var visited = Set<UUID>()
        for record in candidates where !visited.contains(record.id) {
            guard adjacency[record.id] != nil else { continue }

            var stack = [record.id]
            var componentIDs: [UUID] = []
            while let id = stack.popLast() {
                guard visited.insert(id).inserted else { continue }
                componentIDs.append(id)
                for next in adjacency[id] ?? [] where !visited.contains(next) {
                    stack.append(next)
                }
            }

            guard componentIDs.count > 1 else { continue }
            let component = componentIDs.compactMap { recordsByID[$0] }
            guard let keeper = component.max(by: { keeperScore($0) < keeperScore($1) }) else { continue }

            // Star filter: only include records with a direct match to keeper
            var starMembers = [keeper]
            for item in component where item !== keeper {
                let key = PairKey(keeper.id, item.id)
                if let pair = pairByIDs[key], pair.score >= scoreThreshold {
                    starMembers.append(item)
                }
            }
            guard starMembers.count > 1 else { continue }

            let groupID = UUID()
            let memberIDs = starMembers.map(\.id)
            let groupConfidence = starMembers.compactMap { bestConfidence(for: $0, in: memberIDs, pairByIDs: pairByIDs) }.max() ?? .low

            groups += 1
            switch groupConfidence {
            case .high: highGroups += 1
            case .medium: mediumGroups += 1
            case .low: lowGroups += 1
            }

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
                    extraCopies += 1
                } else {
                    item.duplicateDisposition = .review
                    reviewItems += 1
                }
            }
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

    private static func buildIndices(records: [VideoRecord]) -> [[VideoRecord]] {
        var byHash: [String: [VideoRecord]] = [:]
        var byTimecode: [String: [VideoRecord]] = [:]
        var byStem: [String: [VideoRecord]] = [:]

        for record in records {
            if !record.partialMD5.isEmpty && record.sizeBytes > 0 {
                let key = "\(record.streamTypeRaw)|\(record.sizeBytes)|\(record.partialMD5)"
                byHash[key, default: []].append(record)
            }
            if !record.timecode.isEmpty {
                let key = "\(record.streamTypeRaw)|\(record.timecode)|\(durationBucket(record.durationSeconds))"
                byTimecode[key, default: []].append(record)
            }

            let stem = normalizedStem(record.filename)
            if !stem.isEmpty {
                let key = "\(record.streamTypeRaw)|\(stem)|\(durationBucket(record.durationSeconds))"
                byStem[key, default: []].append(record)
            }
        }

        return Array(byHash.values) + Array(byTimecode.values) + Array(byStem.values)
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

    private static let scoringRules: [ScoringRule] = [
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
