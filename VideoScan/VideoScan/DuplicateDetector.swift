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
            return DuplicateAnalysisSummary(
                groups: 0,
                highConfidenceGroups: 0,
                mediumConfidenceGroups: 0,
                lowConfidenceGroups: 0,
                extraCopies: 0,
                reviewItems: 0
            )
        }

        let pairs = buildCandidatePairs(from: candidates)
        guard !pairs.isEmpty else {
            return DuplicateAnalysisSummary(
                groups: 0,
                highConfidenceGroups: 0,
                mediumConfidenceGroups: 0,
                lowConfidenceGroups: 0,
                extraCopies: 0,
                reviewItems: 0
            )
        }

        var adjacency: [UUID: Set<UUID>] = [:]
        var pairByIDs: [PairKey: Candidate] = [:]
        for pair in pairs {
            adjacency[pair.left.id, default: []].insert(pair.right.id)
            adjacency[pair.right.id, default: []].insert(pair.left.id)
            pairByIDs[PairKey(pair.left.id, pair.right.id)] = pair
        }

        let recordsByID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0) })
        var visited = Set<UUID>()
        var groups = 0
        var highGroups = 0
        var mediumGroups = 0
        var lowGroups = 0
        var extraCopies = 0
        var reviewItems = 0

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

            let groupID = UUID()
            let groupConfidence = component.compactMap { bestConfidence(for: $0, in: componentIDs, pairByIDs: pairByIDs) }.max() ?? .low
            let groupReasons = component.flatMap { bestReasons(for: $0, in: componentIDs, pairByIDs: pairByIDs) }
            let reasonText = Array(NSOrderedSet(array: groupReasons)).compactMap { $0 as? String }.joined(separator: "+")

            groups += 1
            switch groupConfidence {
            case .high: highGroups += 1
            case .medium: mediumGroups += 1
            case .low: lowGroups += 1
            }

            for item in component {
                item.duplicateGroupID = groupID
                item.duplicateGroupCount = component.count
                item.duplicateConfidence = bestConfidence(for: item, in: componentIDs, pairByIDs: pairByIDs) ?? groupConfidence
                item.duplicateReasons = bestReasons(for: item, in: componentIDs, pairByIDs: pairByIDs).joined(separator: "+").isEmpty ? reasonText : bestReasons(for: item, in: componentIDs, pairByIDs: pairByIDs).joined(separator: "+")
                item.duplicateBestMatchFilename = keeper === item ? strongestMatchFilename(for: item, in: component, pairByIDs: pairByIDs) : keeper.filename

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

    private static func score(left: VideoRecord, right: VideoRecord) -> Candidate? {
        guard left.streamType == right.streamType else { return nil }

        var score = 0
        var reasons: [String] = []

        if !left.partialMD5.isEmpty && left.partialMD5 == right.partialMD5 && left.sizeBytes == right.sizeBytes {
            score += 8
            reasons.append("hash")
        }

        if !left.timecode.isEmpty && left.timecode == right.timecode {
            score += 4
            reasons.append("timecode")
        }

        if normalizedStem(left.filename) == normalizedStem(right.filename) {
            score += 3
            reasons.append("filename")
        }

        let durationDelta = abs(left.durationSeconds - right.durationSeconds)
        if left.durationSeconds > 0 && right.durationSeconds > 0 {
            if durationDelta <= durationToleranceExact {
                score += 3
                reasons.append("duration")
            } else if durationDelta <= durationToleranceLoose {
                score += 2
                reasons.append("duration")
            }
        }

        if !left.resolution.isEmpty && left.resolution == right.resolution {
            score += 2
            reasons.append("resolution")
        }

        if !left.videoCodec.isEmpty && left.videoCodec == right.videoCodec {
            score += 2
            reasons.append("vcodec")
        }

        if audioSignature(left) == audioSignature(right) {
            score += 2
            reasons.append("audio")
        }

        if !left.tapeName.isEmpty && left.tapeName == right.tapeName {
            score += 1
            reasons.append("tape")
        }

        if let leftDate = left.dateCreatedRaw, let rightDate = right.dateCreatedRaw,
           abs(leftDate.timeIntervalSince(rightDate)) <= creationTolerance {
            score += 1
            reasons.append("created")
        }

        guard score >= 7 else { return nil }

        let confidence: DuplicateConfidence
        if score >= 12 {
            confidence = .high
        } else if score >= 9 {
            confidence = .medium
        } else {
            confidence = .low
        }

        return Candidate(left: left, right: right, score: score, confidence: confidence, reasons: reasons)
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
            return true
        }
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
