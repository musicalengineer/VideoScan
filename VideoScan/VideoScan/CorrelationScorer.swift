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

    static func filenameCorrelationKey(_ filename: String) -> String {
        let stem = filename.hasSuffix("/") ? filename : (filename as NSString).deletingPathExtension
        var parts = stem.split(separator: ".", omittingEmptySubsequences: false).map(String.init)

        // Avid OMFI tape-name — {TapeName}{V|A}{trackNum}.{clipID}.{umidSuffix}
        // e.g. NewTape9V01.4B9C1586.8D8520 → NewTape9.4B9C1586
        // Checked first: more specific than the bare V/A-hex pattern below.
        if parts.count >= 2 {
            let p = parts[0]
            if let range = p.range(of: #"[VAva]\d{1,2}$"#, options: .regularExpression) {
                let tapeName = String(p[p.startIndex..<range.lowerBound])
                let clipID = parts[1]
                if !tapeName.isEmpty && clipID.count >= 4 && clipID.allSatisfy({ $0.isHexDigit }) {
                    return tapeName + "." + clipID
                }
            }
        }

        // Bare V/A + all-hex segment (e.g. 00000.V14BB2CE9D.mxf → 00000._14BB2CE9D)
        for i in parts.indices {
            let p = parts[i]
            if p.count > 1,
               let first = p.first,
               (first == "V" || first == "A" || first == "v" || first == "a"),
               p.dropFirst().allSatisfy({ $0.isHexDigit }) {
                parts[i] = "_" + p.dropFirst()
                return parts.joined(separator: ".")
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
        // Delegates to the shared rubric in CorrelationScorer+Snaps.swift
        // (2026-07-05) — the record path and the off-main snap path must
        // never drift apart.
        guard let (score, confidence, reasons) = scoreParts(
            vKey: vKey, audioFilename: audio.filename,
            vDuration: video.durationSeconds, aDuration: audio.durationSeconds,
            vDate: video.dateCreatedRaw, aDate: audio.dateCreatedRaw,
            vTimecode: video.timecode, aTimecode: audio.timecode,
            vDirectory: video.directory, aDirectory: audio.directory,
            vTape: video.tapeName, aTape: audio.tapeName,
            durationTolerance: durationTolerance,
            timestampTolerance: timestampTolerance
        ) else { return nil }
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

        // Issue #101: the user-facing Find Matching Audio path
        // (formerly "Repair Audio") must NOT
        // surface pairs whose entire score comes from duration +
        // timestamp coincidence. In a 16k-record catalog, plenty of
        // unrelated A and V files have similar duration and creation
        // time by chance — Rick's Donna_by_decade demo was paired
        // with an unrelated Avid orphan MXF on exactly that basis.
        //
        // For findBestPair, require at least one STRUCTURAL signal
        // (path-level or persistent metadata) — the shared
        // `structuralSignals` constant next to scoreParts (one bar for
        // every call site; QA fix 2026-07-15 de-duplicated it). Bulk
        // correlation (scoreCorrelatePair direct callers) keeps the
        // original score >= 3 threshold — it has the broader correlation
        // context and can tolerate duration-only pairs in well-bounded
        // pools.
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
                let hasStructural = !Set(cand.reasons).isDisjoint(with: structuralSignals)
                guard hasStructural else { continue }
                if cand.score > (best?.score ?? -1) {
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
    ///
    /// QA P1-2 (2026-07-05): clearing a selected record must also clear its
    /// PARTNER's back-reference, even when the partner is outside the
    /// selection — otherwise the partner dangles as "paired" forever under
    /// the incremental ledger (legacy full recompute used to self-heal
    /// this; nothing does now). The freed partner honestly returns to
    /// "pending" for the next incremental pass.
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
            if let partner = r.pairedWith, partner.pairedWith === r {
                partner.pairedWith = nil
                partner.pairGroupID = nil
                partner.pairConfidence = nil
            }
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
