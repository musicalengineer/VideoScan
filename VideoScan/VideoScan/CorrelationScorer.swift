import Foundation

// MARK: - CorrelationScorer

/// Pure scoring and indexing helpers for audio/video pair correlation.
/// Extracted from VideoScanModel for testability — all methods are static.
enum CorrelationScorer {

    // MARK: - Types

    struct Candidate {
        let video: VideoRecord
        let audio: VideoRecord
        let score: Int
        let confidence: PairConfidence
        let reasons: [String]
    }

    // MARK: - Filename Key

    /// Normalize filename by stripping V/A prefix (Avid MXF convention).
    /// Only strips when followed by hex digits (e.g., V01A23BC.mxf -> _01A23BC.mxf)
    static func filenameCorrelationKey(_ filename: String) -> String {
        var parts = filename.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        for i in parts.indices {
            let p = parts[i]
            if p.count > 1,
               let first = p.first,
               first == "V" || first == "A" || first == "v" || first == "a",
               p.dropFirst().allSatisfy({ $0.isHexDigit }) {
                parts[i] = "_" + p.dropFirst()
                break
            }
        }
        return parts.joined(separator: ".")
    }

    // MARK: - Audio Pools

    /// Index audio records by filename-correlation key and directory for O(1) lookup.
    static func buildAudioPools(
        from audios: [VideoRecord]
    ) -> (byKey: [String: [VideoRecord]], byDir: [String: [VideoRecord]]) {
        var byKey: [String: [VideoRecord]] = [:]
        var byDir: [String: [VideoRecord]] = [:]
        for a in audios {
            byKey[filenameCorrelationKey(a.filename), default: []].append(a)
            byDir[a.directory, default: []].append(a)
        }
        return (byKey, byDir)
    }

    /// Build the candidate audio pool for a video: indexed lookups first, fall back
    /// to duration/timestamp scan across ALL audios only when the pool is thin.
    static func gatherCandidateAudios(
        for video: VideoRecord,
        vKey: String,
        allAudios: [VideoRecord],
        byKey: [String: [VideoRecord]],
        byDir: [String: [VideoRecord]],
        durationTolerance: Double,
        timestampTolerance: TimeInterval
    ) -> [VideoRecord] {
        var seen = Set<UUID>()
        var pool: [VideoRecord] = []
        for a in byKey[vKey] ?? [] where seen.insert(a.id).inserted { pool.append(a) }
        for a in byDir[video.directory] ?? [] where seen.insert(a.id).inserted { pool.append(a) }
        if pool.count >= 5 { return pool }
        for a in allAudios where !seen.contains(a.id) {
            let durationHit = video.durationSeconds > 0 && a.durationSeconds > 0 &&
                abs(video.durationSeconds - a.durationSeconds) <= durationTolerance
            let timestampHit: Bool
            if let vDate = video.dateCreatedRaw, let aDate = a.dateCreatedRaw {
                timestampHit = abs(vDate.timeIntervalSince(aDate)) <= timestampTolerance
            } else {
                timestampHit = false
            }
            if (durationHit || timestampHit) && seen.insert(a.id).inserted {
                pool.append(a)
            }
        }
        return pool
    }

    // MARK: - Scoring

    /// Score a single video/audio pair and return a Candidate if the minimum
    /// threshold is met. Same weighting as Correlator.swift (filename 4 / duration 3 /
    /// timestamp 3 / timecode 2 / directory 1 / tape 1).
    static func scoreCorrelatePair(
        video: VideoRecord,
        audio: VideoRecord,
        vKey: String,
        durationTolerance: Double,
        timestampTolerance: TimeInterval
    ) -> Candidate? {
        var score = 0
        var reasons: [String] = []

        if vKey == filenameCorrelationKey(audio.filename) { score += 4; reasons.append("filename") }
        if video.durationSeconds > 0 && audio.durationSeconds > 0 &&
           abs(video.durationSeconds - audio.durationSeconds) <= durationTolerance {
            score += 3; reasons.append("duration")
        }
        if let vDate = video.dateCreatedRaw, let aDate = audio.dateCreatedRaw,
           abs(vDate.timeIntervalSince(aDate)) <= timestampTolerance {
            score += 3; reasons.append("timestamp")
        }
        if !video.timecode.isEmpty && video.timecode == audio.timecode {
            score += 2; reasons.append("timecode")
        }
        if video.directory == audio.directory { score += 1; reasons.append("directory") }
        if !video.tapeName.isEmpty && video.tapeName == audio.tapeName {
            score += 1; reasons.append("tape")
        }
        guard score >= 3 else { return nil }

        let confidence: PairConfidence
        if score >= 7 { confidence = .high } else if score >= 4 { confidence = .medium } else { confidence = .low }
        return Candidate(
            video: video, audio: audio,
            score: score, confidence: confidence, reasons: reasons
        )
    }

    // MARK: - Single-file Best-Match (on-demand "Find A/V Pair")

    /// Bucketed match-quality label for the right-click "Find A/V Pair" UI.
    /// Spans the 0–14 score range with a wider top bucket so "Best" stays meaningful.
    enum MatchQuality: String {
        case best = "Best", better = "Better", good = "Good", maybe = "Maybe"

        static func bucket(forScore score: Int) -> MatchQuality {
            if score >= 10 { return .best }
            if score >= 7 { return .better }
            if score >= 4 { return .good }
            return .maybe
        }
    }

    /// Find the single best pair-candidate for one V-only or A-only record.
    /// Scores against every opposite-type record in `allRecords` (cross-volume,
    /// online and offline). Returns nil if no candidate clears the score≥3 floor.
    static func findBestPair(
        for record: VideoRecord,
        in allRecords: [VideoRecord],
        durationTolerance: Double,
        timestampTolerance: TimeInterval
    ) -> Candidate? {
        guard record.streamType == .videoOnly || record.streamType == .audioOnly else {
            return nil
        }
        let isVideo = record.streamType == .videoOnly
        let opposites = allRecords.filter {
            $0.id != record.id && $0.streamType == (isVideo ? .audioOnly : .videoOnly)
        }
        let vKey: String
        if isVideo {
            vKey = filenameCorrelationKey(record.filename)
        } else {
            vKey = ""  // computed per-candidate below
        }

        var best: Candidate?
        for other in opposites {
            let video = isVideo ? record : other
            let audio = isVideo ? other : record
            let key = isVideo ? vKey : filenameCorrelationKey(video.filename)
            if let cand = scoreCorrelatePair(
                video: video, audio: audio, vKey: key,
                durationTolerance: durationTolerance,
                timestampTolerance: timestampTolerance
            ) {
                if best == nil || cand.score > best!.score {
                    best = cand
                }
            }
        }
        return best
    }

    // MARK: - Assignment

    /// Greedy max-score assignment: sort by score descending, claim each pair
    /// unless either side was already matched. Mutates records in place.
    /// Returns log lines describing each pairing.
    static func assignCandidates(
        _ candidates: [Candidate],
        matched: inout Set<UUID>
    ) -> [String] {
        var logLines: [String] = []
        for c in candidates.sorted(by: { $0.score > $1.score }) {
            guard !matched.contains(c.video.id), !matched.contains(c.audio.id) else { continue }
            let gid = UUID()
            c.video.pairedWith = c.audio
            c.video.pairGroupID = gid
            c.video.pairConfidence = c.confidence
            c.audio.pairedWith = c.video
            c.audio.pairGroupID = gid
            c.audio.pairConfidence = c.confidence
            matched.insert(c.video.id)
            matched.insert(c.audio.id)
            logLines.append("  Paired [\(c.confidence.rawValue)] (\(c.reasons.joined(separator: "+"))): \(c.video.filename)  \u{2194}  \(c.audio.filename)")
        }
        return logLines
    }

    // MARK: - Scope Resolution

    /// Select records to re-correlate (all or the selected subset) and clear
    /// their prior pairing so they can be re-paired from scratch.
    static func resolveCorrelateScope(
        records: [VideoRecord],
        selectedIDs: Set<UUID>?
    ) -> [VideoRecord] {
        let scope: [VideoRecord]
        if let ids = selectedIDs, !ids.isEmpty {
            scope = records.filter { ids.contains($0.id) }
        } else {
            scope = records
        }
        for r in scope {
            r.pairedWith = nil
            r.pairGroupID = nil
            r.pairConfidence = nil
        }
        return scope
    }

    // MARK: - Avid Clip ID

    private static let avidMXFPattern = try! NSRegularExpression(
        pattern: #"^\d+\.([AV])([0-9A-Fa-f]+)\.mxf$"#, options: .caseInsensitive
    )

    /// Extract the Avid clip ID from an MXF filename, e.g. "00001.V14D1BBD3F.mxf" -> "14D1BBD3F"
    /// Returns (clipID, isVideo) or nil if the filename doesn't match the Avid pattern.
    static func avidClipID(from filename: String) -> (clipID: String, isVideo: Bool)? {
        let range = NSRange(filename.startIndex..., in: filename)
        guard let match = avidMXFPattern.firstMatch(in: filename, range: range),
              let avRange = Range(match.range(at: 1), in: filename),
              let idRange = Range(match.range(at: 2), in: filename) else { return nil }
        let av = String(filename[avRange]).uppercased()
        let clipID = String(filename[idRange]).uppercased()
        return (clipID, av == "V")
    }

    /// Pick the best record from a set: prefer online, then playable, then largest.
    static func bestCopy(from candidates: [VideoRecord]) -> VideoRecord? {
        candidates.sorted { a, b in
            let aOnline = VolumeReachability.isReachable(path: a.fullPath)
            let bOnline = VolumeReachability.isReachable(path: b.fullPath)
            if aOnline != bOnline { return aOnline }
            if a.isPlayable != b.isPlayable { return a.isPlayable == "Yes" }
            return a.sizeBytes > b.sizeBytes
        }.first
    }
}
